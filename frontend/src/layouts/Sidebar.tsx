import { Sidebar, Menu, useTranslate } from 'react-admin';
import { FaUser, FaFile } from "react-icons/fa";

const CustomSidebar = () => {
  const translate = useTranslate();
  return (
    <Sidebar>
      <Menu>
        <Menu.Item
          to="/client"
          primaryText={translate("client.title")}
          leftIcon={<FaUser />}
        />
        <Menu.Item
          to="/files/"
          primaryText={translate("files.title")}
          leftIcon={<FaFile />}
        />
      </Menu>
    </Sidebar>
  );
};

export default CustomSidebar;